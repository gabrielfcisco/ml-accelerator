library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Buffer de pesos com 4 bancos paralelos (um para cada MAC lane).
-- O host escreve pesos um a um; wr_bank seleciona qual banco recebe a escrita.
-- Durante COMPUTE o controller usa um unico rd_addr compartilhado nos 4 bancos,
-- entregando 4 pesos em paralelo (os 4 neuronios do grupo atual no indice k).
-- Layout para uma camada (M entradas, K neuronios, K mult. de 4):
--   grupo g cobre neuronios (4g, 4g+1, 4g+2, 4g+3)
--   linha do banco lane (=0..3) no grupo g, entrada k: row = g*M + k
--   ou seja, w_lane[row] = peso do neuronio (4g+lane) para a entrada k.
entity weight_buffer is
    generic (
        BANK_DEPTH : integer := 256;
        ADDR_W     : integer := 8
    );
    Port (
        clk      : in  std_logic;
        we       : in  std_logic;
        wr_bank  : in  std_logic_vector(1 downto 0);
        wr_addr  : in  std_logic_vector(ADDR_W-1 downto 0);
        wr_data  : in  std_logic_vector(15 downto 0);
        rd_addr  : in  std_logic_vector(ADDR_W-1 downto 0);
        rd_data0 : out std_logic_vector(15 downto 0);
        rd_data1 : out std_logic_vector(15 downto 0);
        rd_data2 : out std_logic_vector(15 downto 0);
        rd_data3 : out std_logic_vector(15 downto 0)
    );
end weight_buffer;

architecture rtl of weight_buffer is
    type bank_t is array (0 to BANK_DEPTH-1) of std_logic_vector(15 downto 0);
    signal bank0 : bank_t := (others => (others => '0'));
    signal bank1 : bank_t := (others => (others => '0'));
    signal bank2 : bank_t := (others => (others => '0'));
    signal bank3 : bank_t := (others => (others => '0'));
begin

    process(clk)
    begin
        if rising_edge(clk) then
            if we = '1' then
                case wr_bank is
                    when "00"   => bank0(to_integer(unsigned(wr_addr))) <= wr_data;
                    when "01"   => bank1(to_integer(unsigned(wr_addr))) <= wr_data;
                    when "10"   => bank2(to_integer(unsigned(wr_addr))) <= wr_data;
                    when others => bank3(to_integer(unsigned(wr_addr))) <= wr_data;
                end case;
            end if;
        end if;
    end process;

    rd_data0 <= bank0(to_integer(unsigned(rd_addr)));
    rd_data1 <= bank1(to_integer(unsigned(rd_addr)));
    rd_data2 <= bank2(to_integer(unsigned(rd_addr)));
    rd_data3 <= bank3(to_integer(unsigned(rd_addr)));

end rtl;
