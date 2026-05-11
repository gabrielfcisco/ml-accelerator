library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Unidade MAC: acc <= acc + (a * b) quando habilitada.
-- Entradas a e b sao signed 16 bits; acumulador signed 32 bits.
-- clear tem prioridade sobre en e zera o acumulador no proximo edge.
entity mac_unit is
    Port (
        clk     : in  std_logic;
        reset   : in  std_logic;
        clear   : in  std_logic;
        en      : in  std_logic;
        a       : in  std_logic_vector(15 downto 0);
        b       : in  std_logic_vector(15 downto 0);
        acc_out : out std_logic_vector(31 downto 0)
    );
end mac_unit;

architecture rtl of mac_unit is
    signal acc : signed(31 downto 0) := (others => '0');
begin

    process(clk, reset)
    begin
        if reset = '1' then
            acc <= (others => '0');
        elsif rising_edge(clk) then
            if clear = '1' then
                acc <= (others => '0');
            elsif en = '1' then
                acc <= acc + (signed(a) * signed(b));
            end if;
        end if;
    end process;

    acc_out <= std_logic_vector(acc);

end rtl;
